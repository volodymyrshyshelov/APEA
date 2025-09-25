param(
  [Parameter(Mandatory = $true)]
  [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$warnings = New-Object System.Collections.ArrayList

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
    Write-Warning(("⚠️ Cannot set Azure context for subscription {0}. Grant 'Reader'. Identity: {1}. Details: {2}" -f $SubId, $usedAccount, $_.Exception.Message))
    [void]$warnings.Add("No subscription context")
    return $false
  }
}

function Empty-DetailCsv([string]$path) {
  "ResourceName,PolicyDefinitionId,PolicyDefinitionName,PolicyAssignmentName,ExemptionStatus,CompliantStatus,Reason,AnalysisTimestamp,SubscriptionId" | Out-File -FilePath $path -Encoding UTF8
}

function Empty-SummaryCsv([string]$path) {
  "PolicyDefinitionId,PolicyDefinitionName,ObsoleteCount" | Out-File -FilePath $path -Encoding UTF8
}

# ===== начало =====
$connected = Connect-Safe $SubscriptionId
$saName = Ensure-Var "ARTIFACT_STORAGE_ACCOUNT_NAME"
$saRg = Ensure-Var "ARTIFACT_STORAGE_ACCOUNT_RG"
$container = Ensure-Var "STORAGE_CONTAINER_NAME"
$prefix = Ensure-Var "STORAGE_FOLDER_PREFIX"
$basePrefix = "$prefix/$SubscriptionId"

# Ищем самую свежую папку (или создаём штамп)
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$denyBlob = "$basePrefix/$timestamp/deny_$SubscriptionId.csv"
$auditBlob = "$basePrefix/$timestamp/audit_$SubscriptionId.csv"
$finalBlob = "$basePrefix/$timestamp/policyExemptionObsolete.csv"
$summaryBlob= "$basePrefix/$timestamp/policyExemptionSummary.csv"

# Пытаемся прочитать из стораджа; если нельзя — работаем с пустыми файлами
$denyTemp = "$env:TEMP\deny_$SubscriptionId.csv"
$auditTemp = "$env:TEMP\audit_$SubscriptionId.csv"
$finalLocal = "$env:TEMP\policyExemptionObsolete.csv"
$summaryLocal = "$env:TEMP\policyExemptionSummary.csv"
Empty-DetailCsv $denyTemp
Empty-DetailCsv $auditTemp

$ctx = $null
try {
  if ($saName -and $saRg) {
    $ctx = (Get-AzStorageAccount -ResourceGroupName $saRg -Name $saName).Context
  }
  if ($ctx -and $container) {
    try { Get-AzStorageBlobContent -Blob $denyBlob -Container $container -Destination $denyTemp -Context $ctx -Force | Out-Null } catch { }
    try { Get-AzStorageBlobContent -Blob $auditBlob -Container $container -Destination $auditTemp -Context $ctx -Force | Out-Null } catch { }
  } else {
    Write-Warning "⚠️ Storage context/container not available; using empty inputs."
    [void]$warnings.Add("No storage inputs")
  }
} catch {
  Write-Warning(("⚠️ Storage access failed. Details: {0}" -f $_.Exception.Message))
  [void]$warnings.Add("Storage access failed")
}

try { $denyData = Import-Csv $denyTemp } catch { $denyData = @(); Write-Warning "⚠️ Failed to read deny CSV; assuming empty." }
try { $auditData = Import-Csv $auditTemp } catch { $auditData = @(); Write-Warning "⚠️ Failed to read audit CSV; assuming empty." }

Write-Output(("Loaded {0} deny+Exempt records" -f $denyData.Count))
Write-Output(("Loaded {0} audit+Compliant records" -f $auditData.Count))

$now = Get-Date
$obsoleteExemptions = @()
foreach ($ex in $denyData) {
  if ($ex.complianceState -eq "Exempt") {
    $match = $auditData | Where-Object { $_.policyDefinitionId -eq $ex.policyDefinitionId -and $_.resourceName -eq $ex.resourceName } | Select-Object -First 1
    if ($match) {
      $obsoleteExemptions += [pscustomobject]@{
        ResourceName       = $ex.resourceName
        PolicyDefinitionId = $ex.policyDefinitionId
        PolicyDefinitionName = $ex.policyDefinitionName
        PolicyAssignmentName = $ex.policyAssignmentName
        ExemptionStatus    = $ex.complianceState
        CompliantStatus    = $match.complianceState
        Reason             = "POLICY_NOW_COMPLIANT"
        AnalysisTimestamp  = $now.ToString("yyyy-MM-dd HH:mm:ss")
        SubscriptionId     = $SubscriptionId
      }
    }
  }
}

Write-Output(("Total obsolete exemptions found: {0}" -f $obsoleteExemptions.Count))

$summary = $obsoleteExemptions | Group-Object -Property PolicyDefinitionId | ForEach-Object {
  [pscustomobject]@{
    PolicyDefinitionId   = $_.Name
    PolicyDefinitionName = ($_.Group | Select-Object -First 1).PolicyDefinitionName
    ObsoleteCount        = $_.Count
  }
}

if ($obsoleteExemptions.Count -gt 0) {
  $obsoleteExemptions | Export-Csv -Path $finalLocal -NoTypeInformation -Encoding UTF8
} else {
  Empty-DetailCsv $finalLocal
}

if ($summary.Count -gt 0) {
  $summary | Export-Csv -Path $summaryLocal -NoTypeInformation -Encoding UTF8
} else {
  Empty-SummaryCsv $summaryLocal
}

if ($ctx -and $container) {
  try {
    Set-AzStorageBlobContent -File $finalLocal -Container $container -Blob $finalBlob -Context $ctx -Force | Out-Null
    Set-AzStorageBlobContent -File $summaryLocal -Container $container -Blob $summaryBlob -Context $ctx -Force | Out-Null
    Write-Output "Uploaded results:"
    Write-Output(("- {0}" -f $finalBlob))
    Write-Output(("- {0}" -f $summaryBlob))
  } catch {
    Write-Warning(("⚠️ Upload results failed. Details: {0}" -f $_.Exception.Message))
    [void]$warnings.Add("Upload results failed")
  }
} else {
  Write-Warning "⚠️ Storage context unavailable; results kept only on temp disk."
  [void]$warnings.Add("No storage context for upload")
}

Remove-Item $denyTemp,$auditTemp,$finalLocal,$summaryLocal -ErrorAction SilentlyContinue

@{
  Success            = $true
  HasWarnings        = ($warnings.Count -gt 0)
  Warnings           = $warnings
  TotalExemptions    = $denyData.Count
  TotalCompliant     = $auditData.Count
  ObsoleteExemptions = $obsoleteExemptions.Count
  FinalCsvPath       = $finalBlob
  SummaryCsvPath     = $summaryBlob
  AnalysisDate       = $now.ToString("yyyy-MM-dd")
}
