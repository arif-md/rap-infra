#!/usr/bin/env pwsh

# =============================================================================
# Post-Provision Hook: Database Initialization and Permission Grants (LOCAL ONLY)
# =============================================================================
# This script runs AFTER main.bicep deployment completes in LOCAL environments.
# 
# Purpose:
#   1. Grant SQL database permissions to backend managed identity
#   2. Database schema is initialized automatically by Flyway migrations (app startup)
# 
# Environment Behavior:
#   - LOCAL (azd up):     Runs this script using 'az sql db query --auth-type ActiveDirectoryDefault'
#   - GITHUB ACTIONS:     SKIPPED - uses separate grant-sql-permissions.yml workflow job instead
# 
# Why skip in GitHub Actions?
#   - GitHub workflow uses Python + pyodbc with explicit token (more reliable)
#   - Workflow handles firewall cleanup and container restart automatically
#   - Prevents duplicate execution (both hook and workflow would run)
# 
# Prerequisites for local execution:
#   - Azure CLI authenticated as user who is member of RAP-SQL-Admins group
#   - SQL Server has public access enabled (or you're on VNet)
# =============================================================================

Write-Host "==> Running post-provision tasks..." -ForegroundColor Cyan

# Skip in GitHub Actions - the grant-sql-permissions workflow job handles this
if ($env:GITHUB_ACTIONS -eq "true") {
    Write-Host "Detected GitHub Actions environment." -ForegroundColor Yellow
    Write-Host "SQL permissions will be granted by the grant-sql-permissions workflow job." -ForegroundColor Yellow
    Write-Host "Skipping postprovision hook to avoid duplicate execution." -ForegroundColor Yellow
    exit 0
}

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
