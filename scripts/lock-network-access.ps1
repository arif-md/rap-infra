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
# azd env get-value writes errors to stdout (not stderr), so 2>$null is not enough.
# Use $LASTEXITCODE to detect a missing key and avoid capturing the error text.
$appConfigName = azd env get-value appConfigName 2>$null
if ($LASTEXITCODE -ne 0) { $appConfigName = $null }
if ($appConfigName) {
    Write-Host "  Disabling App Config public access: $appConfigName" -ForegroundColor Yellow
    az appconfig update `
        --name $appConfigName `
        --resource-group $rg `
        --enable-public-network false `
        --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ App Config public access disabled." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Could not disable App Config public access (permission or SKU issue) — continuing." -ForegroundColor Yellow
    }
} else {
    Write-Host "  WARNING: appConfigName not in azd env — skipping App Config lockdown." -ForegroundColor Yellow
}

# ── Key Vault ────────────────────────────────────────────────────────────────
# Key Vault has a private endpoint (pe-kv-*) and a linked private DNS zone
# (privatelink.vaultcore.azure.net). Containers inside the VNet resolve the KV
# hostname to the private endpoint IP, so public access can be safely disabled.
#
# Guard: verify the private endpoint actually exists before locking — this
# prevents startup failures if someone runs the script against an environment
# where the KV private endpoint was not provisioned (e.g. VNet disabled later).
if ($kvName) {
    $kvPeName = "pe-$kvName"
    $kvPe = az network private-endpoint show -g $rg -n $kvPeName -o json 2>$null | ConvertFrom-Json
    if ($kvPe -and $kvPe.provisioningState -eq 'Succeeded') {
        Write-Host "  Disabling Key Vault public access: $kvName" -ForegroundColor Yellow
        az keyvault update `
            --name $kvName `
            --resource-group $rg `
            --public-network-access Disabled `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Key Vault public access disabled." -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Could not disable Key Vault public access (permission issue) — continuing." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Key Vault: private endpoint '$kvPeName' not found or not Succeeded — public access left enabled." -ForegroundColor Yellow
        Write-Host "             Run 'azd provision' to create the private endpoint, then re-run this script." -ForegroundColor Gray
    }
} else {
    Write-Host "  WARNING: kvName not in azd env — skipping Key Vault lockdown." -ForegroundColor Yellow
}

Write-Host "==> Network lockdown complete." -ForegroundColor Green
