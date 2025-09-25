# Automation Account operations

function Set-AutomationVariable {
    param(
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [switch]$Encrypted
    )

    try {
        if ($Encrypted) {
            New-AzAutomationVariable `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccountName `
                -Name $Name -Value $Value -Encrypted:$true `
                -Description 'Managed by APEA deployment' -ErrorAction Stop
            Write-Log "Variable '$Name' created successfully (encrypted)"
        }
        else {
            New-AzAutomationVariable `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccountName `
                -Name $Name -Value $Value -Encrypted:$false `
                -Description 'Managed by APEA deployment' -ErrorAction Stop
            Write-Log "Variable '$Name' created successfully"
        }
    }
    catch {
        Write-Log -Level WARN "Create failed for variable '$Name', trying update..."
        try {
            if ($Encrypted) {
                Set-AzAutomationVariable `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $Name -Value $Value -Encrypted:$true -ErrorAction Stop
            }
            else {
                Set-AzAutomationVariable `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $Name -Value $Value -Encrypted:$false -ErrorAction Stop
            }
            Write-Log "Variable '$Name' updated successfully"
        }
        catch {
            Write-Log -Level ERROR "Failed to set variable '$Name': $($_.Exception.Message)"
            throw
        }
    }
}

function Write-DeploymentSummary {
    param([Parameter(Mandatory)][hashtable]$Out)
    Write-Log "Deployment summary:"
    $rows = @()
    
    if ($Out.automation_account_name) {
        $rows += [pscustomobject]@{ 
            Component='Automation Account'; 
            Name=$Out.automation_account_name.value; 
            ResourceGroup=$Out.automation_account_resource_group.value; 
            Id=$Out.automation_account_id.value 
        }
    }
    
    if ($Out.storage_account_name) {
        $rows += [pscustomobject]@{ 
            Component='Storage Account';   
            Name=$Out.storage_account_name.value;   
            ResourceGroup=$Out.storage_account_resource_group.value;   
            Id=$Out.storage_account_id.value 
        }
    }
    
    if ($Out.user_assigned_identity_id -and $Out.user_assigned_identity_id.value) {
        $rows += [pscustomobject]@{ 
            Component='User Assigned MI'; 
            Name=(Split-Path -Leaf $Out.user_assigned_identity_id.value); 
            ResourceGroup=((Select-String -InputObject $Out.user_assigned_identity_id.value -Pattern '/resourceGroups/([^/]+)/').Matches[0].Groups[1].Value); 
            Id=$Out.user_assigned_identity_id.value 
        }
    }
    
    if ($Out.log_analytics_workspace_id -and $Out.log_analytics_workspace_id.value) {
        $rows += [pscustomobject]@{ 
            Component='Log Analytics'; 
            Name=(Split-Path -Leaf $Out.log_analytics_workspace_id.value); 
            ResourceGroup=((Select-String -InputObject $Out.log_analytics_workspace_id.value -Pattern '/resourceGroups/([^/]+)/').Matches[0].Groups[1].Value); 
            Id=$Out.log_analytics_workspace_id.value 
        }
    }
    
    $rows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
}