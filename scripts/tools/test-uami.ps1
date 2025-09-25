# Test UAMI attachment to Automation Account from config
[CmdletBinding()]
param(
    [string]$SubscriptionId,
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

Write-Log -Message "Testing UAMI attachment..."

# Load config
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$rg = $cfg.resource_group_name
$aa = $cfg.automation_account_name
$uamiId = $cfg.user_assigned_identity_resource_id

if (-not $rg -or -not $aa) { throw "Config must contain resource_group_name and automation_account_name." }
if (-not $uamiId) { Write-Log -Level WARN -Message "No user_assigned_identity_resource_id in config."; }

# Set subscription context if provided
if ($SubscriptionId) { & az account set --subscription $SubscriptionId | Out-Null }

# Ensure AA exists and fetch identity
$aaResId = "/subscriptions/$((az account show --query id -o tsv))/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aa"
$aaRes = Az-Json @('resource','show','--ids',$aaResId) -AllowFail

if (-not $aaRes) {
    Write-Log -Level ERROR -Message "Automation Account not found: $aaResId"
    return
}

$type = $aaRes.identity.type
$uamis = @()
if ($aaRes.identity.userAssignedIdentities) {
    $uamis = $aaRes.identity.userAssignedIdentities.PSObject.Properties.Name
}

Write-Log -Message ("Identity.type = {0}" -f $type)
if ($uamis.Count -gt 0) {
    Write-Log -Message ("UserAssignedIdentities count = {0}" -f $uamis.Count)
    foreach ($id in $uamis) { Write-Host " - $id" }
} else {
    Write-Log -Level WARN -Message "No userAssignedIdentities attached to Automation Account."
}

# If config contains UAMI, check it's attached
if ($uamiId) {
    $attached = $uamis -contains $uamiId
    if ($attached) {
        Write-Log -Message "✅ Configured UAMI is attached to Automation Account."
    } else {
        Write-Log -Level WARN -Message "⚠️ Configured UAMI is NOT attached to Automation Account."
    }

    # Also verify the identity resource itself exists
    $idRes = Az-Json @('identity','show','--ids',$uamiId) -AllowFail
    if ($idRes) {
        Write-Log -Message "UAMI resource exists."
        Write-Log -Level DEBUG -Message ("UAMI principalId: " + $idRes.principalId)
    } else {
        Write-Log -Level WARN -Message "UAMI resource not found or no access."
    }
}
