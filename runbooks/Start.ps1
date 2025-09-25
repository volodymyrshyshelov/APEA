param(
  [Parameter(Mandatory = $true)]
  [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

function Get-UamiClientId {
  # 1) Пробуем явный clientId из переменной
  try {
    $cid = Get-AutomationVariable -Name "USER_ASSIGNED_MI_CLIENT_ID"
    if ($cid -and $cid -match '^[0-9a-fA-F-]{36}$') { return $cid }
  } catch { }

  # 2) Пробуем resourceId (потребуется хотя бы временный токен)
  try {
    $rid = Get-AutomationVariable -Name "USER_ASSIGNED_MI_RESOURCE_ID"
    if ($rid) {
      # Подключимся системной MI, чтобы сходить в ARM
      try { Connect-AzAccount -Identity | Out-Null } catch { }
      $api = "$rid?api-version=2023-01-31"
      $resp = Invoke-AzRestMethod -Method GET -Path $api
      $cid2 = (($resp.Content | ConvertFrom-Json).properties.clientId)
      if ($cid2 -and $cid2 -match '^[0-9a-fA-F-]{36}$') { return $cid2 }
    }
  } catch { }

  return $null
}

function Connect-Safe {
  param([string]$SubId)
  $usedAccount = $null
  try {
    $uamiClientId = Get-UamiClientId
    if ($uamiClientId) {
      Connect-AzAccount -Identity -AccountId $uamiClientId | Out-Null
      $usedAccount = "UAMI:$uamiClientId"
    } else {
      Connect-AzAccount -Identity | Out-Null
      $usedAccount = "SystemAssigned"
    }
  } catch {
    Write-Warning(("⚠️ Connect-AzAccount failed. Details: {0}" -f $_.Exception.Message))
    return @{ Connected = $false; Account = $usedAccount }
  }

  try {
    Set-AzContext -Subscription $SubId | Out-Null
    $ctx = Get-AzContext
    Write-Output(("✅ Connected. Tenant: {0}; Subscription: {1}; Account: {2}" -f $ctx.Tenant.Id, $ctx.Subscription.Id, $ctx.Account.Id))
    return @{ Connected = $true; Account = $ctx.Account.Id }
  } catch {
    $ctx = Get-AzContext
    $acc = if ($ctx -and $ctx.Account) { $ctx.Account.Id } else { $usedAccount }
    Write-Warning(("⚠️ Cannot set Azure context for subscription {0}. Grant 'Reader' (и 'Monitoring Reader') на /subscriptions/{0}. Identity: {1}. Details: {2}" -f $SubId, $acc, $_.Exception.Message))
    return @{ Connected = $false; Account = $acc }
  }
}

$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

Write-Output(("Starting policy compliance analysis for subscription: {0}" -f $SubscriptionId))
Write-Output(("Timestamp: {0}" -f $timestamp))

$connectInfo = Connect-Safe -SubId $SubscriptionId

$collect = .\KqlCollect.ps1 -SubscriptionId $SubscriptionId
if (-not $collect) {
  $collect = @{ Success = $false; HasWarnings = $true; Warnings = @("KqlCollect returned nothing.") }
}

$analysis = .\PolicyCompliance.ps1 -SubscriptionId $SubscriptionId
if (-not $analysis) {
  $analysis = @{ Success = $false; HasWarnings = $true; Warnings = @("PolicyCompliance returned nothing.") }
}

Write-Output "=== ANALYSIS COMPLETE ==="
Write-Output(("Subscription: {0}" -f $SubscriptionId))
Write-Output(("Total exemptions analyzed: {0}" -f $analysis.TotalExemptions))
Write-Output(("Total compliant policies: {0}" -f $analysis.TotalCompliant))
Write-Output(("Obsolete exemptions found: {0}" -f $analysis.ObsoleteExemptions))
Write-Output(("Final report (detailed): {0}" -f $analysis.FinalCsvPath))
Write-Output(("Final report (summary): {0}" -f $analysis.SummaryCsvPath))
Write-Output(("Analysis date: {0}" -f $analysis.AnalysisDate))

@{
  Success      = $true
  HasWarnings  = ($collect.HasWarnings -or $analysis.HasWarnings -or -not $connectInfo.Connected)
  Warnings     = @(
    if (-not $connectInfo.Connected) { "Azure context not set; working in degraded mode under identity: $($connectInfo.Account)" }
    $collect.Warnings
    $analysis.Warnings
  ) | Where-Object { $_ }
  SubscriptionId = $SubscriptionId
  Timestamp      = $timestamp
  Collect        = $collect
  Analysis       = $analysis
}
