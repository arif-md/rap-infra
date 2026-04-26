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
# Key Vault public access is intentionally NOT disabled here, even in VNet mode.
#
# Reason: there is no Key Vault private endpoint in the current architecture.
# The Key Vault is managed outside azd (by ensure-keyvault.sh) and no private
# endpoint is provisioned for it. Spring Cloud Azure App Config resolves KV
# references (jwt.secret, aad-client-secret) at Spring Boot startup by calling
# the KV URI directly from the container. Without a private endpoint, the
# container must reach KV over the public endpoint — disabling it causes
# startup failures.
#
# To lock down KV in VNet mode, first provision a KV private endpoint in the
# same subnet and add a privatelink.vaultcore.azure.net DNS zone. Then this
# script can safely set --public-network-access Disabled.
Write-Host "  Key Vault: public access left enabled (no private endpoint provisioned — required for App Config KV reference resolution)." -ForegroundColor Gray

Write-Host "==> Network lockdown complete." -ForegroundColor Green
