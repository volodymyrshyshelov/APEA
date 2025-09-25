# Manage schedules separately (create / link schedule to a runbook)
# Uses Az.Automation cmdlets (stable) — no 'az automation job-schedule' dependency
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$RunbookName = 'Start',
    [string]$ScheduleName = 'APEA-Daily',
    [string]$Time = '06:00',       # UTC time HH:mm
    [string]$TimeZone = 'UTC',
    [int]$IntervalDays = 1
)

$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Automation -ErrorAction Stop

. (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\core-utils.ps1")

if (-not (Test-Path $ConfigPath)) { throw "Config '$ConfigPath' not found." }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$aa  = $cfg.automation_account_name
$rg  = $cfg.resource_group_name
if (-not $aa -or -not $rg) { throw "Config must include automation_account_name and resource_group_name." }

Write-Log "Managing schedules for AA='$aa' RG='$rg' runbook='$RunbookName'"

# Ensure Az context
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Subscription.Id -ne $SubscriptionId) {
    Write-Log "Setting context to subscription $SubscriptionId"
    Set-AzContext -Subscription $SubscriptionId | Out-Null
}

# Ensure schedule exists
$startUtc = Get-Date -Date "$(Get-Date -Format yyyy-MM-dd)T$Time:00Z"
if ($startUtc -lt (Get-Date).ToUniversalTime().AddMinutes(6)) {
    $startUtc = (Get-Date).ToUniversalTime().AddMinutes(10)
}
$existing = Get-AzAutomationSchedule -AutomationAccountName $aa -ResourceGroupName $rg -Name $ScheduleName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Log "Creating schedule '$ScheduleName' (start=$($startUtc.ToString('o')), every $IntervalDays day(s))"
    New-AzAutomationSchedule `
        -AutomationAccountName $aa `
        -ResourceGroupName $rg `
        -Name $ScheduleName `
        -StartTime $startUtc `
        -TimeZone $TimeZone `
        -DayInterval $IntervalDays | Out-Null
} else {
    Write-Log "Schedule '$ScheduleName' already exists"
}

# Link schedule to runbook
$link = Get-AzAutomationScheduledRunbook `
    -AutomationAccountName $aa `
    -ResourceGroupName $rg `
    -ScheduleName $ScheduleName `
    -ErrorAction SilentlyContinue | Where-Object { $_.RunbookName -eq $RunbookName }

if (-not $link) {
    Write-Log "Linking schedule '$ScheduleName' to runbook '$RunbookName'"
    Register-AzAutomationScheduledRunbook `
        -AutomationAccountName $aa `
        -ResourceGroupName $rg `
        -RunbookName $RunbookName `
        -ScheduleName $ScheduleName | Out-Null
} else {
    Write-Log "Runbook '$RunbookName' is already linked to '$ScheduleName'"
}

Write-Log "Schedule management complete."
