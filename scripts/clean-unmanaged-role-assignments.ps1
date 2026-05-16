#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Removes role assignments that would conflict with Azure Deployment Stack
    ownership, preventing RoleAssignmentExists (ARM 409) failures.
.DESCRIPTION
    Runs as a preprovision hook immediately before 'azd up'. For each role
    assignment that Bicep creates, any existing assignment for that role scoped
    to that resource is deleted before the deployment. The deployment stack then
    recreates the assignment under its ownership.

    WHY query per resource scope (not --resource-group):
      az role assignment list --resource-group X only returns assignments whose
      scope IS the RG (or above). Assignments scoped to child resources within
      the RG (App Config store, SQL Server) are NOT returned -- they live at the
      resource scope, not the RG scope.

    ROLE ASSIGNMENTS CLEANED:
      App Configuration Data Reader (scope: App Config store -> backend identity)
      SQL Server Contributor        (scope: SQL Server     -> sql-admin identity)
#>

param()

$ErrorActionPreference = "Stop"

$azureResourceGroup = $env:AZURE_RESOURCE_GROUP

if (-not $azureResourceGroup) {
    Write-Host "  i  AZURE_RESOURCE_GROUP not set -- skipping." -ForegroundColor Gray
    exit 0
}

Write-Host ""
Write-Host "Pre-deployment role assignment cleanup (RG: $azureResourceGroup)"

$appConfigDataReaderRole  = "516239f1-63e1-4d78-a4de-a74fb236a071"
$sqlServerContributorRole = "6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"

$deletedCount = 0

function Invoke-DeleteAtScope {
    param(
        [string]$ScopeId,
        [string]$RoleGuid,
        [string]$Label
    )

    if (-not $ScopeId) {
        Write-Host "  i  ${Label}: resource not found in RG -- skipping." -ForegroundColor Gray
        return
    }

    $resourceName = $ScopeId.Split('/')[-1]
    Write-Host "  Querying assignments scoped to $resourceName..." -ForegroundColor Gray

    $json = az role assignment list --scope $ScopeId --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { $json = "[]" }
    $assignments = $json | ConvertFrom-Json

    $roleGuidLower = $RoleGuid.ToLower()
    $matched = @($assignments | Where-Object { $_.roleDefinitionId.ToLower() -match $roleGuidLower })

    if ($matched.Count -eq 0) {
        Write-Host "  OK ${Label}: no existing assignment at $resourceName -- stack will create it." -ForegroundColor Green
        return
    }

    foreach ($ra in $matched) {
        $shortId = $ra.id.Split('/')[-1]
        Write-Host "  DEL ${Label}: deleting $shortId..." -ForegroundColor Cyan
        az role assignment delete --ids $ra.id
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERR Failed to delete $($ra.id)" -ForegroundColor Red
            exit 1
        }
        $script:deletedCount++
        Write-Host "  OK ${Label}: deleted -- stack will recreate under its ownership." -ForegroundColor Green
    }
}

$appConfigId = $null
try {
    $appConfigId = az appconfig list --resource-group $azureResourceGroup --query "[0].id" --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $appConfigId = $null }
} catch {}

Invoke-DeleteAtScope -ScopeId $appConfigId -RoleGuid $appConfigDataReaderRole -Label "App Config Data Reader"

$sqlServerId = $null
try {
    $sqlServerId = az sql server list --resource-group $azureResourceGroup --query "[0].id" --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $sqlServerId = $null }
} catch {}

Invoke-DeleteAtScope -ScopeId $sqlServerId -RoleGuid $sqlServerContributorRole -Label "SQL Server Contributor"

Write-Host ""
if ($deletedCount -gt 0) {
    Write-Host "Removed $deletedCount role assignment(s) -- deployment stack will recreate and own them." -ForegroundColor Cyan
} else {
    Write-Host "No conflicting role assignments found -- deployment stack will create them fresh." -ForegroundColor Green
}
exit 0
