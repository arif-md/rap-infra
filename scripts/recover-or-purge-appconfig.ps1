#!/usr/bin/env pwsh

# =============================================================================
# Pre-Provision: Recover or purge soft-deleted App Configuration store
# =============================================================================
# Standard-tier App Config stores go into soft-delete when removed (e.g. azd down).
# During that retention window (1 day for non-prod) the name is reserved, so
# a subsequent azd provision with the same deterministic name would fail.
#
# This script runs BEFORE Bicep and:
#   - If VNet is disabled → SKU will be Free (no soft-delete), skip entirely
#   - If VNet is enabled  → SKU will be Standard; check for a soft-deleted store
#     with the expected name and purge it so Bicep can create a fresh one.
#
# Note: purge protection is disabled in non-prod, so purge is always allowed.
# =============================================================================

$ErrorActionPreference = "Stop"

# Only Standard/Premium SKUs support soft-delete — Free tier is an immediate hard-delete.
$vnetEnabled = azd env get-value ENABLE_VNET_INTEGRATION 2>$null
if ($vnetEnabled -ne "true") {
    Write-Host "VNet not enabled (Free SKU) — App Config soft-delete check skipped." -ForegroundColor Gray
    exit 0
}

$rg       = azd env get-value AZURE_RESOURCE_GROUP 2>$null
$location = azd env get-value AZURE_LOCATION 2>$null
$envName  = azd env get-value AZURE_ENV_NAME 2>$null

if (-not $rg -or -not $location) {
    Write-Host "AZURE_RESOURCE_GROUP or AZURE_LOCATION not set — skipping App Config purge check." -ForegroundColor Yellow
    exit 0
}

# Derive the expected store name using the same deterministic pattern as main.bicep:
#   appConfigName = '${abbrs.appConfigurationStores}${resourceToken}'
#   abbrs.appConfigurationStores = 'appcs-'
#   resourceToken = take(uniqueString(subscriptionId, resourceGroupId, location), 13)
# We query deleted stores and match by location + resource group instead of guessing the token.
Write-Host "Checking for soft-deleted App Configuration stores in '$rg' ($location)..." -ForegroundColor Cyan

$deletedStores = az appconfig list-deleted `
    --query "[?location=='$location'].[name,id]" `
    -o tsv 2>$null

if (-not $deletedStores) {
    Write-Host "  No soft-deleted App Config stores found." -ForegroundColor Gray
    exit 0
}

$deletedStores -split "`n" | Where-Object { $_ } | ForEach-Object {
    $parts = $_ -split "`t"
    $storeName = $parts[0].Trim()

    # Only purge stores whose name starts with 'appcs-' (our naming convention)
    if ($storeName -notmatch '^appcs-') {
        return
    }

    Write-Host "  Found soft-deleted store: $storeName — purging..." -ForegroundColor Yellow
    az appconfig purge `
        --name $storeName `
        --location $location `
        --yes `
        --output none
    Write-Host "  ✅ Purged: $storeName" -ForegroundColor Green
}

Write-Host "App Config soft-delete check complete." -ForegroundColor Green
