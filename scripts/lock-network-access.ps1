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
# Bicep keeps publicNetworkAccess=Enabled during deployment so ARM can write
# key-values. Now that provision succeeded, disable it so only PE traffic works.
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
# Key Vault is externally managed (not in Bicep deployment stack), but the
# private endpoint is deployed by Bicep. Lock down public access here so only
# containers inside the VNet (via PE) can reach the vault.
$kvName = azd env get-value keyVaultName 2>$null
if ($kvName) {
    Write-Host "  Disabling Key Vault public access: $kvName" -ForegroundColor Yellow
    az keyvault update `
        --name $kvName `
        --resource-group $rg `
        --public-network-access Disabled `
        --output none
    Write-Host "  ✅ Key Vault public access disabled." -ForegroundColor Green
} else {
    Write-Host "  WARNING: keyVaultName not in azd env — skipping Key Vault lockdown." -ForegroundColor Yellow
}

Write-Host "==> Network lockdown complete." -ForegroundColor Green
