# Health check utilities: environment/tools, config dump, access basics
[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$Environment,
    [switch]$Config,
    [string]$SubscriptionId,
    [string]$ConfigPath = "$(Split-Path -Parent (Split-Path -Parent $PSScriptRoot))\config\resources.json"
)

$ErrorActionPreference = 'Stop'

# Reuse common logging
. (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\core-utils.ps1")

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [switch]$AllowFail
    )
    $out = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFail) { return $null }
        throw "az $($Args -join ' ') failed: $out"
    }
    if (-not $out) { return $null }
    try { return $out | ConvertFrom-Json } catch { return $null }
}

# Если не указан ни один флаг — делаем Full
if (-not ($Full -or $Environment -or $Config)) { $Full = $true }

# ---------- ENV / TOOLS ----------
if ($Environment -or $Full) {
    Write-Log -Message "Checking tools..."

    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Log -Message "az:        OK"
    } else {
        Write-Log -Level ERROR -Message "az:        NOT FOUND"
    }

    if (Get-Command terraform -ErrorAction SilentlyContinue) {
        Write-Log -Message "terraform: OK"
    } else {
        Write-Log -Level ERROR -Message "terraform: NOT FOUND"
    }

    $tfv = terraform version 2>$null
    if ($tfv) { Write-Log -Level DEBUG -Message ("Terraform: " + ($tfv | Out-String).Trim()) }

    $azvRaw = az version 2>$null
    if ($azvRaw) {
        try {
            $azv = $azvRaw | ConvertFrom-Json
            Write-Log -Level DEBUG -Message ("Azure CLI: " + $azv.'azure-cli')
        } catch {
            Write-Log -Level DEBUG -Message ("Azure CLI: " + ($azvRaw | Out-String).Trim())
        }
    }

    $mods = @('Az.Accounts','Az.Automation')
    $missing = @()
    foreach ($m in $mods) {
        if (-not (Get-Module -ListAvailable $m)) { $missing += $m }
    }
    if ($missing.Count -eq 0) {
        Write-Log -Message "Az modules present."
    } else {
        Write-Log -Level WARN -Message ("Missing Az modules: " + ($missing -join ', '))
    }
}

# ---------- CONFIG ----------
$cfg = $null
if ($Config -or $Full) {
    if (Test-Path $ConfigPath) {
        try {
            $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            Write-Log -Message "Config loaded."
            # Показать ключевые поля
            $cfg | Select-Object `
                location, resource_group_name, automation_account_name,
                storage_account_name, storage_container_name, storage_folder_prefix,
                log_analytics_workspace_name, user_assigned_identity_resource_id,
                hybrid_worker_group_name |
                Format-List | Out-String | Write-Host
        } catch {
            Write-Log -Level ERROR -Message "Failed to parse config: $($_.Exception.Message)"
        }
    } else {
        Write-Log -Level ERROR -Message "Config path not found: $ConfigPath"
    }
}

# ---------- ACCESS / RG / MI ----------
if ($Full) {
    if ($SubscriptionId) {
        try {
            az account set --subscription $SubscriptionId | Out-Null
        } catch { Write-Log -Level WARN -Message "Unable to set subscription context to $SubscriptionId" }
    }

    $acct = Invoke-AzJson -Args @('account','show') -AllowFail
    if ($acct) {
        Write-Log -Message ("Logged in as: {0} / tenant {1} / sub {2}" -f $acct.user.name,$acct.tenantId,$acct.id)
    } else {
        Write-Log -Level WARN -Message "Not logged in to Azure CLI."
    }

    if ($cfg -and $cfg.resource_group_name) {
        $rgName = $cfg.resource_group_name
        $exists = (& az group exists --name $rgName)
        Write-Log -Message ("RG '{0}' exists: {1}" -f $rgName, $exists)
    }

    if ($cfg -and $cfg.user_assigned_identity_resource_id) {
        $uami = Invoke-AzJson -Args @('identity','show','--ids',$cfg.user_assigned_identity_resource_id) -AllowFail
        Write-Log -Message ("UAMI reachable: {0}" -f ([bool]$uami))
    }
}

# End
