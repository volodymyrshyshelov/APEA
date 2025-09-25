# Minimal helper to guide/install Hybrid Runbook Worker on this machine
[CmdletBinding()]
param(
    [string]$WorkspaceId,     # optional LAW workspace
    [string]$WorkspaceKey     # optional LAW key
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\core-utils.ps1")

Write-Log "Hybrid Worker installation helper"
Write-Log "This script validates prerequisites and shows next steps."

if (-not ([Environment]::Is64BitOperatingSystem)) { Write-Log -Level WARN "32-bit OS is not supported." }

# Check .NET & PowerShell remoting basics (lightweight)
$psVersion = $PSVersionTable.PSVersion.ToString()
Write-Log "PowerShell version: $psVersion"

# OMS/MMA is deprecated, but many setups still use it for HW. Provide info only.
Write-Log -Level WARN "For new deployments consider Azure Automation Hybrid worker extension on Arc/VMSS. This helper does not auto-install legacy MMA."

Write-Log "If you still need classic HW on Windows VM:"
Write-Host @"
1) Install Azure Automation Hybrid Worker MSI (or via extension).
2) Onboard to Log Analytics (optional): WorkspaceId/Key if using Update Mgmt.
3) Create/Join Hybrid Worker Group in your Automation Account.
"@

if ($WorkspaceId -and $WorkspaceKey) {
    Write-Log "Provided LAW workspace parameters (masked)."
}
