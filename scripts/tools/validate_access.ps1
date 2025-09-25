# Validate access (RBAC) for current principal on Subscription and RG
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ConfigPath = "$(Split-Path -Parent (Split-Path -Parent $PSScriptRoot))\config\resources.json"
)

$ErrorActionPreference = 'Stop'

# Reuse common logging
. (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\core-utils.ps1")

function Az-Json {
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFail)
    $out = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFail) { return $null }
        throw "az $($Args -join ' ') failed: $out"
    }
    if (-not $out) { return $null }
    try { return $out | ConvertFrom-Json } catch { return $null }
}

Write-Log -Message "Validating access in subscription $SubscriptionId"

# Установим контекст подписки
& az account set --subscription $SubscriptionId | Out-Null

# Кто мы
$acct = Az-Json @('account','show')
$currentUpn = $acct.user.name
Write-Log -Message "Current user: $currentUpn"

# Подготовим assignee (можно UPN)
$assignee = $currentUpn

# Прочитаем RG из конфига (если есть)
$rgName = $null
if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $rgName = $cfg.resource_group_name
    } catch {
        Write-Log -Level WARN -Message "Config not parsed, skipping RG scope details."
    }
}

# Роли на уровне подписки (ТОЛЬКО scope, без --all)
Write-Log -Message "Fetching subscription role assignments..."
$subScope = "/subscriptions/$SubscriptionId"
$subRoles = Az-Json @('role','assignment','list','--assignee',$assignee,'--scope',$subScope,'--include-inherited') -AllowFail
if ($subRoles) {
    $subRoleNames = $subRoles | Select-Object -ExpandProperty roleDefinitionName -Unique
    Write-Log -Message "Your roles on subscription:"
    if ($subRoleNames) { $subRoleNames | ForEach-Object { Write-Host " - $_" } } else { Write-Host " (none)" }
} else {
    Write-Log -Level WARN -Message "No subscription-level role assignments found or not accessible."
}

# Роли на уровне RG (если указан)
if ($rgName) {
    Write-Log -Message "Fetching RG role assignments for '$rgName'..."
    $rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$rgName"
    $rgRoles = Az-Json @('role','assignment','list','--assignee',$assignee,'--scope',$rgScope,'--include-inherited') -AllowFail
    if ($rgRoles) {
        $rgRoleNames = $rgRoles | Select-Object -ExpandProperty roleDefinitionName -Unique
        if ($rgRoleNames) {
            Write-Log -Message "Your roles on RG '$rgName':"
            $rgRoleNames | ForEach-Object { Write-Host " - $_" }
        } else {
            Write-Log -Message "No explicit roles on RG '$rgName' (may inherit from subscription)."
        }
    } else {
        Write-Log -Level WARN -Message "No RG-level role assignments found or not accessible."
    }
} else {
    Write-Log -Level WARN -Message "RG name not in config, skipped RG scope check."
}
