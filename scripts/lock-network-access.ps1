#!/usr/bin/env pwsh

# =============================================================================
# Post-Provision: Lock public network access for App Config + Key Vault
# =============================================================================
# When VNet integration is enabled, both services are reachable via private
# endpoints from within the VNet. Public access is kept open during the Bicep
# deployment (so ARM can write App Config key-values), then locked down here.
#
# When VNet is disabled, this script is a no-op — public access stays open
# and the free-tier App Config SKU is used (no private endpoint overhead).
# =============================================================================

$vnetEnabled = azd env get-value ENABLE_VNET_INTEGRATION 2>$null
if ($vnetEnabled -ne "true") {
    Write-Host "VNet not enabled — network lockdown skipped." -ForegroundColor Gray
    exit 0
}

$rg = azd env get-value AZURE_RESOURCE_GROUP 2>$null
if (-not $rg) {
    Write-Host "AZURE_RESOURCE_GROUP not set — skipping network lockdown." -ForegroundColor Yellow
    exit 0
}

Write-Host "==> Locking public network access (VNet mode)..." -ForegroundColor Cyan

# ── App Configuration ────────────────────────────────────────────────────────
# App Config has no "trusted Azure services" bypass: ARM deployment engine
# writes key-values over the public endpoint, so we keep public access open
# during Bicep deployment and lock it down here in postprovision.
$appConfigName = azd env get-value appConfigName 2>$null
if ($appConfigName) {
    Write-Host "  Disabling App Config public access: $appConfigName" -ForegroundColor Yellow
    az appconfig update `
        --name $appConfigName `
        --resource-group $rg `
        --enable-public-network false `
        --output none
    Write-Host "  ✅ App Config public access disabled." -ForegroundColor Green
} else {
    Write-Host "  WARNING: appConfigName not in azd env — skipping App Config lockdown." -ForegroundColor Yellow
}

# ── Key Vault ────────────────────────────────────────────────────────────────
# Key Vault public access is intentionally NOT restricted here.
# Azure Container Apps resolves KV secret references at deployment time from
# Azure's shared infrastructure (outside the VNet). Disabling public access
# causes 'azd deploy' to fail when it creates new revisions that validate
# KV secret refs. Security is provided by access policies scoped to the
# backend managed identity — the public endpoint cannot be used without
# the correct identity credentials.
Write-Host "  Key Vault: public access left enabled (required for Container Apps secret ref resolution)." -ForegroundColor Gray

Write-Host "==> Network lockdown complete." -ForegroundColor Green
