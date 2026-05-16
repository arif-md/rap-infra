#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Detects and removes role assignments that exist in Azure but are not managed
    by the current deployment stack, allowing the stack to recreate and own them.
.DESCRIPTION
    Azure Deployment Stacks cannot idempotently adopt a role assignment they don't
    own — they throw RoleAssignmentExists (ARM 409). This script detects that
    condition and deletes the unmanaged assignments so the next 'azd up' can
    recreate them under proper stack ownership.

    BEHAVIOR BY CASE:
      No stack exists (fresh provision)    -> exits without changes
      Assignment is in the stack           -> left untouched (stack manages it)
      Assignment exists, NOT in the stack  -> deleted so stack can recreate it
      Assignment doesn't exist             -> nothing to do (stack will create it)
      azd down then up                     -> stack deletes on down; nothing to
                                             clean; stack recreates on up

    ROLE ASSIGNMENTS CHECKED:
      App Configuration Data Reader (scoped to App Config -> backend identity)
      SQL Server Contributor        (scoped to SQL Server -> sql-admin identity)
#>

param()

$ErrorActionPreference = "Stop"

$azureEnvName      = $env:AZURE_ENV_NAME
$azureResourceGroup = $env:AZURE_RESOURCE_GROUP

if (-not $azureEnvName -or -not $azureResourceGroup) {
    Write-Host "  i  AZURE_ENV_NAME or AZURE_RESOURCE_GROUP not set — skipping." -ForegroundColor Gray
    exit 0
}

$stackName = "azd-$azureEnvName"

Write-Host ""
Write-Host "Checking for unmanaged role assignments (stack: $stackName, RG: $azureResourceGroup)..."

# ── Get deployment stack's managed resource IDs ──────────────────────────────
$stackResources = @()
try {
    $stackJson = az stack group show `
        --name $stackName `
        --resource-group $azureResourceGroup `
        --query "resources[*].id" `
        --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $stackJson) {
        $stackResources = ($stackJson | ConvertFrom-Json) | ForEach-Object { $_.ToLower() }
    }
} catch {
    # Stack doesn't exist yet — fresh provision
}

if ($stackResources.Count -eq 0) {
    Write-Host "  i  Stack '$stackName' not found or has no managed resources — nothing to clean." -ForegroundColor Gray
    exit 0
}

# ── Role definition IDs ───────────────────────────────────────────────────────
$appConfigDataReaderRole  = "516239f1-63e1-4d78-a4de-a74fb236a071"
$sqlServerContributorRole = "6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"

$deletedCount = 0

function Invoke-CheckAndClean {
    param(
        [string]$ScopeId,
        [string]$RoleId,
        [string]$Label
    )

    if (-not $ScopeId) {
        Write-Host "  i  ${Label}: resource not found in RG — skipping." -ForegroundColor Gray
        return
    }

    $assignmentIds = @()
    try {
        $json = az role assignment list `
            --scope  $ScopeId `
            --role   $RoleId `
            --query  "[].id" `
            --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $json) {
            $assignmentIds = $json | ConvertFrom-Json
        }
    } catch {}

    if ($assignmentIds.Count -eq 0) {
        Write-Host "  i  ${Label}: no assignment found — stack will create it." -ForegroundColor Gray
        return
    }

    foreach ($raId in $assignmentIds) {
        $raIdLower = $raId.ToLower()
        if ($script:stackResources -contains $raIdLower) {
            Write-Host "  ✅ ${Label}: assignment is stack-managed — leaving untouched." -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  ${Label}: assignment exists but is NOT managed by stack '$stackName'." -ForegroundColor Yellow
            Write-Host "          Deleting so the deployment stack can recreate and own it..." -ForegroundColor Gray
            az role assignment delete --ids $raId --output none
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ✗  Failed to delete assignment: $raId" -ForegroundColor Red
                exit 1
            }
            $script:deletedCount++
            Write-Host "  🗑️  ${Label}: unmanaged assignment deleted." -ForegroundColor Cyan
        }
    }
}

# ── App Configuration Data Reader ────────────────────────────────────────────
$appConfigId = $null
try {
    $appConfigId = az appconfig list `
        --resource-group $azureResourceGroup `
        --query "[0].id" `
        --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $appConfigId = $null }
} catch {}

Invoke-CheckAndClean -ScopeId $appConfigId -RoleId $appConfigDataReaderRole -Label "App Config Data Reader"

# ── SQL Server Contributor ────────────────────────────────────────────────────
$sqlServerId = $null
try {
    $sqlServerId = az sql server list `
        --resource-group $azureResourceGroup `
        --query "[0].id" `
        --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $sqlServerId = $null }
} catch {}

Invoke-CheckAndClean -ScopeId $sqlServerId -RoleId $sqlServerContributorRole -Label "SQL Server Contributor"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
if ($deletedCount -gt 0) {
    Write-Host "Cleaned $deletedCount unmanaged role assignment(s) — deployment stack will recreate and own them." -ForegroundColor Cyan
} else {
    Write-Host "All role assignments are either stack-managed or absent — no action needed." -ForegroundColor Green
}
exit 0
