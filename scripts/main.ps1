[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ConfigPath = "$(Split-Path -Parent $PSScriptRoot)\config\resources.json"
)

# Import core utilities (Write-Log, guards, etc.)
. (Join-Path $PSScriptRoot "deploy\core-utils.ps1")

function Show-Menu {
    Clear-Host
    $subDisplay = $(if ($SubscriptionId) { $SubscriptionId } else { 'Not set' })
    Write-Host "=== APEA Deployment Manager ===" -ForegroundColor Cyan
    Write-Host "Current Subscription: $subDisplay" -ForegroundColor White
    Write-Host "Config: $ConfigPath" -ForegroundColor White

    Write-Host "`n--- HealthCheck ---" -ForegroundColor Green
    Write-Host " 1. Full Health Check (environment + config + access)"
    Write-Host " 2. Environment Check (tools, modules)"
    Write-Host " 3. Config Dump & Validation"
    Write-Host " 4. Access Validation (RBAC)"
    Write-Host " 5. Test UAMI Connection"
    Write-Host " 6. Install Hybrid Worker"
    Write-Host " 7. Bootstrap OAuth Refresh"

    Write-Host "`n--- Deployment ---" -ForegroundColor Yellow
    Write-Host " 8.  Full Deployment (Terraform + Runbooks)"
    Write-Host " 9.  Terraform Only (infrastructure)"
    Write-Host "10. Terraform Plan (preview)"
    Write-Host "11. Destroy (SAFE - only our resource group)"

    Write-Host "`n--- Maintenance ---" -ForegroundColor Magenta
    Write-Host "12. Runbooks Update & Publish (all)"
    Write-Host "13. Manage Schedules"
    Write-Host "14. Convert Cron to Schedule"

    Write-Host "`n15. Exit"
}

function Ensure-Sub {
    param([string]$ActionName)
    if (-not $script:SubscriptionId -or $script:SubscriptionId.Trim() -eq "") {
        $script:SubscriptionId = Read-Host "Enter Subscription ID for '$ActionName'"
    }
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Select an option [1-15]"

    try {
        switch ($choice) {
            # --- HealthCheck ---
            '1' {
                & (Join-Path $PSScriptRoot "tools\healthcheck.ps1") -Full -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath
            }
            '2' {
                & (Join-Path $PSScriptRoot "tools\healthcheck.ps1") -Environment -ConfigPath $ConfigPath
            }
            '3' {
                & (Join-Path $PSScriptRoot "tools\healthcheck.ps1") -Config -ConfigPath $ConfigPath
            }
            '4' {
                Ensure-Sub -ActionName 'Access Validation'
                & (Join-Path $PSScriptRoot "tools\validate_access.ps1") -SubscriptionId $SubscriptionId
            }
            '5' {
                Ensure-Sub -ActionName 'Test UAMI Connection'
                & (Join-Path $PSScriptRoot "tools\test-uami.ps1") -SubscriptionId $SubscriptionId
            }
            '6' {
                & (Join-Path $PSScriptRoot "tools\install-hybrid-worker.ps1")
            }
            '7' {
                & (Join-Path $PSScriptRoot "tools\bootstrap_oauth_refresh.ps1")
            }

            # --- Deployment ---
            '8' {
                Ensure-Sub -ActionName 'Full Deployment'
                & (Join-Path $PSScriptRoot "deploy\deploy.ps1") -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath
            }
            '9' {
                Ensure-Sub -ActionName 'Terraform Only'
                & (Join-Path $PSScriptRoot "deploy\deploy.ps1") -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath -OnlyTerraform
            }
            '10' {
                Ensure-Sub -ActionName 'Terraform Plan'
                & (Join-Path $PSScriptRoot "deploy\deploy.ps1") -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath -PlanOnly
            }
            '11' {
                Ensure-Sub -ActionName 'Destroy'
                $confirm = Read-Host "WARNING: This will DESTROY only our resource group. Type 'yes' to continue"
                if ($confirm -eq 'yes') {
                    & (Join-Path $PSScriptRoot "deploy\deploy.ps1") -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath -Destroy
                } else {
                    Write-Host "Skipped destroy." -ForegroundColor Yellow
                }
            }

            # --- Maintenance ---
            '12' {
                Ensure-Sub -ActionName 'Runbooks Update & Publish'
                & (Join-Path $PSScriptRoot "maintenance\publish-runbooks.ps1") -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath
            }
            '13' {
                Ensure-Sub -ActionName 'Manage Schedules'
                & (Join-Path $PSScriptRoot "maintenance\manage-schedules.ps1") -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath
            }
            '14' {
                # Requires Python in PATH
                python (Join-Path $PSScriptRoot "tools\cron_to_schedule.py")
            }

            '15' {
                Write-Host "Exiting..." -ForegroundColor Green
                break
            }

            default {
                Write-Host "Invalid selection. Press Enter to continue..." -ForegroundColor Red
                [void] (Read-Host)
            }
        }
    }
    catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        if ($_.InvocationInfo.ScriptLineNumber) {
            Write-Host ("At line: {0}" -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
        }
    }

    if ($choice -ne '15') {
        Write-Host "`nPress Enter to return to menu..." -ForegroundColor Gray
        [void] (Read-Host)
    }
}