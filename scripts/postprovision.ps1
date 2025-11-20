#!/usr/bin/env pwsh

# =============================================================================
# Post-Provision Hook: Database Initialization and Permission Grants
# =============================================================================
# This script runs AFTER main.bicep deployment completes.
# It ensures:
# 1. Backend managed identity has SQL database permissions
# 2. Database schema is initialized (via Flyway migrations in the app)
#
# Note: Flyway migrations run automatically when the Spring Boot app starts,
# so we only need to ensure the managed identity has permissions.
# =============================================================================

Write-Host "==> Running post-provision tasks..." -ForegroundColor Cyan

# Check if SQL Database is enabled
$enableSql = azd env get-value ENABLE_SQL_DATABASE 2>$null
if (-not $enableSql) { $enableSql = "true" }

if ($enableSql -ne "true") {
    Write-Host "SQL Database is disabled. Skipping post-provision SQL tasks." -ForegroundColor Yellow
    exit 0
}

# Run the SQL permissions script (it handles all the checks)
Write-Host "Ensuring SQL permissions are configured..." -ForegroundColor Yellow

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ensureSqlScript = Join-Path $scriptDir "ensure-sql-permissions.ps1"

if (Test-Path $ensureSqlScript) {
    & $ensureSqlScript
} else {
    Write-Host "WARNING: ensure-sql-permissions.ps1 not found at $ensureSqlScript" -ForegroundColor Yellow
    Write-Host "Skipping SQL permission grants." -ForegroundColor Yellow
}

Write-Host "==> Post-provision tasks complete!" -ForegroundColor Green
Write-Host ""
Write-Host "ℹ️  Database schema will be initialized automatically by Flyway migrations" -ForegroundColor Cyan
Write-Host "   when the backend container app starts for the first time." -ForegroundColor Cyan
Write-Host ""

$backendAppName = azd env get-value BACKEND_APP_NAME 2>$null
$resourceGroup = azd env get-value AZURE_RESOURCE_GROUP 2>$null

if ($backendAppName -and $resourceGroup) {
    Write-Host "   Check backend logs with:" -ForegroundColor Cyan
    Write-Host "   az containerapp logs show -n $backendAppName -g $resourceGroup --tail 100" -ForegroundColor White
}
