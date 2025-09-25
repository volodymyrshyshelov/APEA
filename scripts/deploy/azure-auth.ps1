# Azure authentication functions

function Test-ManagedIdentityAvailable {
    try {
        Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' -Headers @{ Metadata='true' } -TimeoutSec 2 | Out-Null
        return $true
    } catch { 
        return $false 
    }
}

function Connect-Azure {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [switch]$ForceInteractive
    )

    # Сброс env для Terraform
    $env:ARM_CLIENT_ID=$null; $env:ARM_CLIENT_SECRET=$null; $env:ARM_SUBSCRIPTION_ID=$null
    $env:ARM_TENANT_ID=$null; $env:ARM_USE_MSI=$null; $env:ARM_USE_AZUREAD=$null

    $ctx = [ordered]@{ 
        AuthType=$null; 
        TenantId=$null; 
        SubscriptionName=$null; 
        SecretPayload=$null 
    }

    if (Test-ManagedIdentityAvailable) {
        Write-Log "Attempting Managed Identity auth."
        $mi = & az login --identity 2>$null
        if ($LASTEXITCODE -eq 0) {
            $acct = & az account show | ConvertFrom-Json
            $ctx.AuthType='ManagedIdentity'; 
            $ctx.TenantId=$acct.tenantId; 
            $env:ARM_USE_MSI='true'
            Write-Log "Authenticated via Managed Identity"
        }
    }

    if (-not $ctx.AuthType) {
        $acct = & az account show 2>$null | ConvertFrom-Json
        if ($acct) { 
            Write-Log "Using existing Azure CLI session (tenant $($acct.tenantId))."
            $ctx.AuthType='AzureCliSession'; 
            $ctx.TenantId=$acct.tenantId 
        }
    }

    if (-not $ctx.AuthType -and $ForceInteractive) {
        Write-Log -Level WARN 'Device code login requested. Follow the instructions below to authenticate.'
        & az login --use-device-code
        $deadline=(Get-Date).AddSeconds(180)
        do { 
            Start-Sleep 3
            $acct=& az account show 2>$null | ConvertFrom-Json
        } while (-not $acct -and (Get-Date) -lt $deadline)
        
        if (-not $acct) { throw 'Interactive login did not complete within 3 minutes.' }
        $ctx.AuthType='Interactive'; 
        $ctx.TenantId=$acct.tenantId; 
        $env:ARM_USE_AZUREAD='true'
    }

    if (-not $ctx.AuthType) {
        Write-Log -Level WARN "Creating ephemeral Service Principal for deployment."
        $spName="APEA-AutoSP-$((Get-Date).ToString('yyyyMMddHHmmss'))"
        $sp = & az ad sp create-for-rbac --name $spName --role Contributor --scopes "/subscriptions/$SubscriptionId" --sdk-auth | ConvertFrom-Json
        $ctx.AuthType='ServicePrincipal'; 
        $ctx.TenantId=$sp.tenantId; 
        $ctx.SecretPayload=$sp
        $env:ARM_CLIENT_ID=$sp.clientId; 
        $env:ARM_CLIENT_SECRET=$sp.clientSecret; 
        $env:ARM_TENANT_ID=$sp.tenantId
    }

    & az account set --subscription $SubscriptionId | Out-Null
    $acc=& az account show | ConvertFrom-Json
    $env:ARM_SUBSCRIPTION_ID=$SubscriptionId

    if (-not $ctx.AuthType) { 
        $ctx.AuthType='AzureCliSession'; 
        $ctx.TenantId=$acc.tenantId; 
        $env:ARM_USE_AZUREAD='true' 
    }

    if ($ctx.AuthType -eq 'ManagedIdentity' -and -not $env:ARM_TENANT_ID) { 
        $env:ARM_TENANT_ID=$acc.tenantId 
    }

    $ctx.SubscriptionName=$acc.name
    return $ctx
}