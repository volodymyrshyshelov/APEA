# Simple bootstrap to ensure fresh Azure CLI device login (when needed)
[CmdletBinding()]
param(
    [switch]$ForceInteractive
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\core-utils.ps1")

try {
    $acc = az account show 2>$null | ConvertFrom-Json
    if ($acc) {
        Write-Log "Azure CLI already logged in as $($acc.user.name)."
        if ($ForceInteractive) {
            Write-Log -Level WARN "Forcing device login..."
            az login --use-device-code | Out-Null
        }
    } else {
        Write-Log -Level WARN "No active Azure CLI session. Starting device login..."
        az login --use-device-code | Out-Null
    }
    $acc2 = az account show | ConvertFrom-Json
    Write-Log "Active account: $($acc2.user.name) / sub $($acc2.id)"
} catch {
    Write-Log -Level ERROR "OAuth bootstrap failed: $($_.Exception.Message)"
    throw
}
