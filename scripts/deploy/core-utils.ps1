# Core utilities and logging functions

$ErrorActionPreference = 'Stop'

# ---------------------------
# ЛОГИРОВАНИЕ И ШАГИ
# ---------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG','STEP')] [string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('u')
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'DEBUG' { 'Gray' }
        'STEP'  { 'Magenta' }
        default { 'Cyan' }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$AllowFail
    )
    Write-Log -Level STEP -Message "Starting: $Name"
    try {
        $result = & $Action
        Write-Log -Message "Completed: $Name"
        return $result
    }
    catch {
        Write-Log -Level ERROR -Message "Step failed: $Name - $($_.Exception.Message)"
        if ($AllowFail) {
            Write-Log -Level WARN -Message "Continuing after failure (AllowFail)."
            return $null
        }
        throw
    }
}

function Test-CommandPresent { 
    param([Parameter(Mandatory)][string]$Name) 
    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue) 
}

function Test-StringNotEmpty { 
    param([string]$Value) 
    return -not [string]::IsNullOrWhiteSpace($Value) 
}