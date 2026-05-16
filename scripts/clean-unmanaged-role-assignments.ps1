#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Removes role assignments that would conflict with Azure Deployment Stack
    ownership, preventing RoleAssignmentExists (ARM 409) failures.
.DESCRIPTION
    Runs as a preprovision hook immediately before 'azd up'. For each role
    assignment that Bicep unconditionally creates, any existing assignment for
    that role on that resource is deleted before the deployment. The deployment
    stack then recreates the assignment under its ownership.

    This handles both cases:
      Assignment is unmanaged (pre-stack or orphaned) -> delete -> stack creates it
      Assignment is stack-managed from a prior run    -> delete -> stack recreates it
    Either way the stack ends up owning a fresh assignment with no ARM 409 conflict.

    ROLE ASSIGNMENTS CLEANED:
      App Configuration Data Reader (scope: App Config store -> backend identity)
      SQL Server Contributor        (scope: SQL Server     -> sql-admin identity)
#>

param()

$ErrorActionPreference = "Stop"

$azureResourceGroup = $env:AZURE_RESOURCE_GROUP

if (-not $azureResourceGroup) {
    Write-Host "  i  AZURE_RESOURCE_GROUP not set — skipping." -ForegroundColor Gray
    exit 0
}

Write-Host ""
Write-Host "Pre-deployment role assignment cleanup (RG: $azureResourceGroup)..."

# ── Role definition IDs ───────────────────────────────────────────────────────
$appConfigDataReaderRole  = "516239f1-63e1-4d78-a4de-a74fb236a071"
$sqlServerContributorRole = "6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"

$deletedCount = 0

# Invoke-DeleteIfExists <scope-resource-id> <role-definition-id> <label>
#
# Queries role assignments AT EXACTLY the given resource scope via the Azure REST
# API (atScope() filter) and deletes any that match the role definition GUID.
#
# WHY REST API instead of 'az role assignment list --scope --role':
#   The CLI's --role filter constructs a subscription-specific role definition ID
#   path (/subscriptions/{current-sub}/providers/Microsoft.Authorization/roleDefinitions/{guid})
#   for its OData $filter. If the existing assignment was created under a different
#   subscription context (or using a canonical path), the filter produces no results
#   even though the assignment exists — hence the silent empty return and the
#   subsequent RoleAssignmentExists (ARM 409) during 'azd up'.
function Invoke-DeleteIfExists {
    param(
        [string]$ScopeId,
        [string]$RoleId,
        [string]$Label
    )

    if (-not $ScopeId) {
        Write-Host "  i  ${Label}: resource not found in RG — skipping." -ForegroundColor Gray
        return
    }

    $resourceName = $ScopeId.Split('/')[-1]
    Write-Host "  i  ${Label}: checking assignments on $resourceName..." -ForegroundColor Gray

    # Query assignments AT exactly this resource scope using REST API + atScope() filter.
    # Use JMESPath contains() on roleDefinitionId — stable substring match on the GUID
    # regardless of the subscription path prefix.
    $assignmentIds = @()
    try {
        $url = "https://management.azure.com${ScopeId}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()"
        $json = az rest `
            --method GET `
            --url $url `
            --query "value[?contains(properties.roleDefinitionId, '${RoleId}')].id" `
            --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $json) {
            $assignmentIds = $json | ConvertFrom-Json
        }
    } catch {}

    if ($assignmentIds.Count -eq 0) {
        Write-Host "  ✅ ${Label}: no existing assignment — stack will create it fresh." -ForegroundColor Green
        return
    }

    foreach ($raId in $assignmentIds) {
        $raShortId = $raId.Split('/')[-1]
        Write-Host "  i  ${Label}: deleting: $raShortId" -ForegroundColor Gray
        az role assignment delete --ids $raId --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ✗  Failed to delete assignment: $raId" -ForegroundColor Red
            exit 1
        }
        $script:deletedCount++
        Write-Host "  🗑️  ${Label}: deleted — stack will recreate under its ownership." -ForegroundColor Cyan
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

Invoke-DeleteIfExists -ScopeId $appConfigId -RoleId $appConfigDataReaderRole -Label "App Config Data Reader"

# ── SQL Server Contributor ────────────────────────────────────────────────────
$sqlServerId = $null
try {
    $sqlServerId = az sql server list `
        --resource-group $azureResourceGroup `
        --query "[0].id" `
        --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $sqlServerId = $null }
} catch {}

Invoke-DeleteIfExists -ScopeId $sqlServerId -RoleId $sqlServerContributorRole -Label "SQL Server Contributor"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
if ($deletedCount -gt 0) {
    Write-Host "Removed $deletedCount role assignment(s) — deployment stack will recreate and own them." -ForegroundColor Cyan
} else {
    Write-Host "No conflicting role assignments found — deployment stack will create them fresh." -ForegroundColor Green
}
exit 0
