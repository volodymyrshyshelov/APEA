param(
  [Parameter(Mandatory = $true)]
  [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$warnings = New-Object System.Collections.ArrayList

# ===== общие вспомогательные =====
function Ensure-Var([string]$name, [switch]$Optional) {
  try {
    $v = Get-AutomationVariable -Name $name
    if ([string]::IsNullOrWhiteSpace($v) -and -not $Optional) {
      Write-Warning(("⚠️ Automation variable '{0}' is empty." -f $name))
      [void]$warnings.Add("Variable '$name' is empty")
    }
    return $v
  } catch {
    if (-not $Optional) {
      Write-Warning(("⚠️ Automation variable '{0}' not found." -f $name))
      [void]$warnings.Add("Variable '$name' not found")
    }
    return $null
  }
}

function Get-UamiClientId {
  try {
    $cid = Get-AutomationVariable -Name "USER_ASSIGNED_MI_CLIENT_ID"
    if ($cid -and $cid -match '^[0-9a-fA-F-]{36}$') { return $cid }
  } catch { }
  try {
    $rid = Get-AutomationVariable -Name "USER_ASSIGNED_MI_RESOURCE_ID"
    if ($rid) {
      try { Connect-AzAccount -Identity | Out-Null } catch { }
      $resp = Invoke-AzRestMethod -Method GET -Path ("{0}?api-version=2023-01-31" -f $rid)
      $cid2 = (($resp.Content | ConvertFrom-Json).properties.clientId)
      if ($cid2 -and $cid2 -match '^[0-9a-fA-F-]{36}$') { return $cid2 }
    }
  } catch { }
  return $null
}

function Connect-Safe([string]$SubId) {
  $usedAccount = $null
  try {
    $cid = Get-UamiClientId
    if ($cid) {
      Connect-AzAccount -Identity -AccountId $cid | Out-Null; $usedAccount = "UAMI:$cid"
    } else {
      Connect-AzAccount -Identity | Out-Null; $usedAccount = "SystemAssigned"
    }
  } catch {
    Write-Warning(("⚠️ Connect-AzAccount failed. Details: {0}" -f $_.Exception.Message))
    [void]$warnings.Add("Connect failed")
    return $false
  }
  try {
    Set-AzContext -Subscription $SubId | Out-Null
    $ctx = Get-AzContext
    Write-Output(("✅ Connected. Tenant: {0}; Subscription: {1}; Account: {2}" -f $ctx.Tenant.Id, $ctx.Subscription.Id, $ctx.Account.Id))
    return $true
  } catch {
    Write-Warning(("⚠️ Cannot set Azure context for subscription {0}. Grant 'Reader' (и 'Monitoring Reader'). Identity: {1}. Details: {2}" -f $SubId, $usedAccount, $_.Exception.Message))
    [void]$warnings.Add("No subscription context")
    return $false
  }
}

function Parse-Workspace([string]$ResourceId) {
  if (-not $ResourceId) { return $null }
  $m = [regex]::Match($ResourceId, '/subscriptions/[^/]+/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.OperationalInsights/workspaces/(?<name>[^/]+)', 'IgnoreCase')
  if ($m.Success) {
    [pscustomobject]@{ ResourceGroup = $m.Groups['rg'].Value; Name = $m.Groups['name'].Value }
  } else { $null }
}

function Empty-Csv([string]$path) {
  "name,resourceName,location,subscriptionId,type,policyDefinitionName,policyDefinitionId,policyAssignmentName,complianceState" | Out-File -FilePath $path -Encoding UTF8
}

# ===== начало выполнения =====
$connected = Connect-Safe $SubscriptionId
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

$lawId = Ensure-Var "LOG_ANALYTICS_WORKSPACE_RESOURCE_ID"
$saName = Ensure-Var "ARTIFACT_STORAGE_ACCOUNT_NAME"
$saRg = Ensure-Var "ARTIFACT_STORAGE_ACCOUNT_RG"
$container = Ensure-Var "STORAGE_CONTAINER_NAME"
$prefix = Ensure-Var "STORAGE_FOLDER_PREFIX"

$wsParts = Parse-Workspace $lawId
$basePath = "$prefix/$SubscriptionId/$timestamp"

Write-Output(("Base path: {0}" -f $basePath))

# Локальные CSV создадим всегда
$denyFile = "$env:TEMP\deny_$SubscriptionId.csv"
$auditFile = "$env:TEMP\audit_$SubscriptionId.csv"
Empty-Csv $denyFile
Empty-Csv $auditFile

# Попробуем получить контекст LAW и выполнить запросы
if ($connected -and $wsParts) {
  try {
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $wsParts.ResourceGroup -Name $wsParts.Name
    Write-Output(("Using Log Analytics workspace: {0}" -f $workspace.Name))

@"
 PolicyResources
 | where type == 'microsoft.policyinsights/policystates'
 | where properties.subscriptionId == '$SubscriptionId'
 | where properties.complianceState == 'Exempt'
 | where properties.policyDefinitionAction == 'deny'
 | extend resourceName = split(properties.resourceId,'/')[-1]
 | extend resourceId = properties.resourceId
 | extend policyDefinitionId = properties.policyDefinitionId
 | extend policyDefinitionName = split(properties.policyDefinitionId,'/')[-1]
 | extend policyAssignmentName = properties.policyAssignmentName
 | extend policyAssignmentId = properties.policyAssignmentId
 | extend complianceState = properties.complianceState
 | project name, id, resourceName, location, subscriptionId, type, policyDefinitionName, policyDefinitionId, policyAssignmentId, policyAssignmentName, complianceState
"@ | Set-Variable -Name denyQuery

@"
 PolicyResources
 | where type == 'microsoft.policyinsights/policystates'
 | where properties.complianceState == 'Compliant'
 | where properties.policyDefinitionAction == 'audit'
 | extend resourceName = split(properties.resourceId,'/')[-1]
 | extend resourceId = properties.resourceId
 | extend policyDefinitionId = properties.policyDefinitionId
 | extend policyDefinitionName = split(properties.policyDefinitionId,'/')[-1]
 | extend policyAssignmentName = properties.policyAssignmentName
 | extend complianceState = properties.complianceState
 | project name, id, resourceName, location, subscriptionId, type, policyDefinitionName, policyDefinitionId, policyAssignmentName, complianceState
"@ | Set-Variable -Name auditQuery

    Write-Output "Executing deny+Exempt query..."
    $denyResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $denyQuery -Timespan (New-TimeSpan -Days 7)

    Write-Output "Executing audit+Compliant query..."
    $auditResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $auditQuery -Timespan (New-TimeSpan -Days 7)

    if ($denyResult.Results -and $denyResult.Results.Count -gt 0) {
      $denyResult.Results | Select-Object @(
        'name','resourceName','location',
        @{Name='subscriptionId';Expression={$SubscriptionId}},
        'type','policyDefinitionName','policyDefinitionId','policyAssignmentName','complianceState'
      ) | Export-Csv -Path $denyFile -NoTypeInformation -Encoding UTF8
      Write-Output(("Deny+Exempt data exported: {0} records" -f $denyResult.Results.Count))
    } else {
      Write-Warning "No deny+Exempt data found."
    }

    if ($auditResult.Results -and $auditResult.Results.Count -gt 0) {
      $auditResult.Results | Select-Object @(
        'name','resourceName','location',
        @{Name='subscriptionId';Expression={$SubscriptionId}},
        'type','policyDefinitionName','policyDefinitionId','policyAssignmentName','complianceState'
      ) | Export-Csv -Path $auditFile -NoTypeInformation -Encoding UTF8
      Write-Output(("Audit+Compliant data exported: {0} records" -f $auditResult.Results.Count))
    } else {
      Write-Warning "No audit+Compliant data found."
    }
  } catch {
    Write-Warning(("⚠️ LAW step failed. Details: {0}" -f $_.Exception.Message))
    [void]$warnings.Add("LAW step failed")
  }
} elseif (-not $wsParts) {
  Write-Warning "⚠️ LOG_ANALYTICS_WORKSPACE_RESOURCE_ID is missing or invalid."
  [void]$warnings.Add("LAW id invalid")
}

# Попытка загрузить CSV в Blob
$denyBlob = "$basePath/deny_$SubscriptionId.csv"
$auditBlob = "$basePath/audit_$SubscriptionId.csv"

try {
  if ($saName -and $saRg) {
    $ctx = (Get-AzStorageAccount -ResourceGroupName $saRg -Name $saName).Context
  }
  if ($ctx -and $container) {
    Set-AzStorageBlobContent -File $denyFile -Container $container -Blob $denyBlob -Context $ctx -Force | Out-Null
    Set-AzStorageBlobContent -File $auditFile -Container $container -Blob $auditBlob -Context $ctx -Force | Out-Null
    Write-Output "Files uploaded to blob storage:"
    Write-Output(("- {0}" -f $denyBlob))
    Write-Output(("- {0}" -f $auditBlob))
  } else {
    Write-Warning "⚠️ Storage context/container not available. Skipping upload."
    [void]$warnings.Add("No storage upload")
  }
} catch {
  Write-Warning(("⚠️ Upload failed. Details: {0}" -f $_.Exception.Message))
  [void]$warnings.Add("Upload failed")
}

Remove-Item $denyFile,$auditFile -ErrorAction SilentlyContinue

@{
  Success     = $true
  HasWarnings = ($warnings.Count -gt 0)
  Warnings    = $warnings
  DenyCsvPath = $denyBlob
  AuditCsvPath= $auditBlob
  FinalPath   = "$basePath"
  Timestamp   = $timestamp
}
