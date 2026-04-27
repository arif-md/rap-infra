#!/usr/bin/env pwsh
# =============================================================================
# Pre-Provision: Detect "azd down/up on retained-MI environment" and auto-set
# FORCE_SQL_SETUP_TAG so that the sql-setup ACI actually runs.
# =============================================================================
#
# WHY THIS IS NEEDED — content-based detection limitation:
#
#   sql-setup.bicep uses a content hash as `forceUpdateTag`. ARM caches the
#   result: if the tag hasn't changed since the last run, the ACI is skipped
#   and the cached "success" is returned immediately.
#
#   Before managed-identity retention was introduced, every azd down/up
#   recreated the MIs with NEW clientIds → hash changed → ACI ran. Now that
#   MIs survive azd down, clientIds stay the same → hash is unchanged → ACI
#   is skipped even though the SQL database (which WAS deleted by azd down)
#   is brand-new and empty.
#
# DETECTION LOGIC:
#   IF  backend managed identity exists (survived azd down via MI retention)
#   AND SQL server does not exist yet (was deleted by azd down)
#   THEN set FORCE_SQL_SETUP_TAG = current timestamp
#
#   This changes the forceUpdateTag hash, forcing ARM to actually run the ACI.
#   The tag is deliberately left set (a fixed value causes no-op on re-runs)
#   and will be cleared by the user or the CI workflow after the first success.
# =============================================================================

$ErrorActionPreference = "Stop"

$rg      = $env:AZURE_RESOURCE_GROUP
$envName = $env:AZURE_ENV_NAME

if (-not $rg -or -not $envName) {
    Write-Host "  ensure-sql-setup: AZURE_RESOURCE_GROUP or AZURE_ENV_NAME not set — skipping." -ForegroundColor Gray
    exit 0
}

# BACKEND_IDENTITY_NAME is exported by ensure-identities.ps1 (runs before this)
$backendMiName = azd env get-value BACKEND_IDENTITY_NAME 2>$null
if (-not $backendMiName) {
    Write-Host "  ensure-sql-setup: BACKEND_IDENTITY_NAME not set — ensure-identities.ps1 must run first." -ForegroundColor Gray
    exit 0
}

# Check if the backend MI already exists (i.e., this is an azd down/up, not a fresh deploy)
$miExists = az identity show --resource-group $rg --name $backendMiName --query name -o tsv 2>$null
if (-not $miExists) {
    # Fresh deploy — MIs will be created by ensure-identities.ps1 just before this.
    # sql-setup will run naturally (new deploymentScript resource → no cached state).
    Write-Host "  ensure-sql-setup: Fresh deploy detected (MI '$backendMiName' absent) — no action needed." -ForegroundColor Gray
    exit 0
}

# MI exists — check if the SQL server is also present
$sqlServer = az sql server list --resource-group $rg --query "[0].name" -o tsv 2>$null

if ($sqlServer) {
    # SQL server exists — check if the database itself exists
    $sqlDbName = "sqldb-raptor-$envName"
    $dbExists = az sql db show --resource-group $rg --server $sqlServer --name $sqlDbName --query name -o tsv 2>$null
    if ($dbExists) {
        Write-Host "  ensure-sql-setup: SQL database '$sqlDbName' exists — no action needed." -ForegroundColor Gray
        exit 0
    }
    Write-Host "  ensure-sql-setup: SQL server exists but database '$sqlDbName' is absent." -ForegroundColor Yellow
} else {
    Write-Host "  ensure-sql-setup: SQL server absent in '$rg'." -ForegroundColor Yellow
}

# MI present but SQL database absent → azd down was run on an environment with
# MI retention. The new database will be empty and sql-setup must re-run.
$tag = Get-Date -Format "yyyyMMddHHmmss"
Write-Host "  ensure-sql-setup: Managed identities retained but SQL database gone." -ForegroundColor Yellow
Write-Host "  Setting FORCE_SQL_SETUP_TAG=$tag to force sql-setup re-run on this deployment." -ForegroundColor Yellow
azd env set FORCE_SQL_SETUP_TAG $tag | Out-Null
Write-Host "  FORCE_SQL_SETUP_TAG set. After 'azd up' succeeds, clear it with:" -ForegroundColor Gray
Write-Host "    azd env set FORCE_SQL_SETUP_TAG ''" -ForegroundColor Gray
exit 0
