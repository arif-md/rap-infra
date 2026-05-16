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
Write-Host "Pre-deployment role assignment cleanup (RG: $azureResourceGroup)"

# ── Role definition GUIDs to remove before deploying ─────────────────────────
$appConfigDataReaderRole  = "516239f1-63e1-4d78-a4de-a74fb236a071"
$sqlServerContributorRole = "6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"
$targetRoles = @($appConfigDataReaderRole, $sqlServerContributorRole)

# ── Fetch ALL role assignments in the resource group ─────────────────────────
# We deliberately do NOT pass --role. The --role flag adds an OData $filter on
# roleDefinitionId using a subscription-specific path that silently returns empty
# when Azure stored the assignment's roleDefinitionId with a different path format
# (e.g. uppercase GUID, different subscription prefix). Fetching all and filtering
# locally in PowerShell avoids the case-sensitivity and path-format mismatches.
Write-Host "  Fetching all role assignments in RG..." -ForegroundColor Gray
$allJson = az role assignment list `
    --resource-group $azureResourceGroup `
    --include-inherited `
    --output json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $allJson) { $allJson = "[]" }
$allAssignments = $allJson | ConvertFrom-Json
Write-Host "  Scanning $($allAssignments.Count) assignment(s) for target roles..." -ForegroundColor Gray

# ── Filter assignments whose roleDefinitionId GUID matches our targets ────────
# roleDefinitionId in Azure responses often uses uppercase GUIDs, e.g.
#   /subscriptions/.../roleDefinitions/516239F1-63E1-4D78-A4DE-A74FB236A071
# PowerShell -match is case-insensitive so we can safely match against our lowercase GUIDs.
$conflicting = $allAssignments | Where-Object {
    $rdId = $_.roleDefinitionId
    $targetRoles | Where-Object { $rdId -match $_ }
}

if ($conflicting.Count -eq 0) {
    Write-Host "  ✅ No conflicting role assignments found — deployment stack will create them fresh." -ForegroundColor Green
    exit 0
}

# ── Delete each conflicting assignment ───────────────────────────────────────
$deletedCount = 0
foreach ($ra in $conflicting) {
    $shortId = $ra.id.Split('/')[-1]
    Write-Host "  🗑  Deleting $shortId  (scope: $($ra.scope))..." -ForegroundColor Cyan
    az role assignment delete --ids $ra.id
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗  Failed to delete $($ra.id)" -ForegroundColor Red
        exit 1
    }
    $deletedCount++
    Write-Host "  ✅  Deleted — stack will recreate under its ownership." -ForegroundColor Green
}

Write-Host ""
Write-Host "Removed $deletedCount role assignment(s) — deployment stack will recreate and own them." -ForegroundColor Cyan
exit 0
