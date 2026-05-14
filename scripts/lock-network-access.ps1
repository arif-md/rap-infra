#!/usr/bin/env pwsh

# =============================================================================
# Post-Provision: Lock public network access for Key Vault
# =============================================================================
# When VNet integration is enabled, Key Vault is reachable via a private
# endpoint from within the VNet. Public access can be safely disabled after
# deployment — containers use private routing via the DNS zone.
#
# App Config public access is intentionally NOT locked here. ARM (Bicep) writes
# key-values over the public endpoint (App Config has no 'trusted Azure services'
# bypass). Locking public access creates a Forbidden race condition on the next
# deployment. RBAC (Managed Identity Data Reader) protects the data plane.
#
# When VNet is disabled, this script is a no-op.
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

# ── Key Vault ────────────────────────────────────────────────────────────────
# Key Vault has a private endpoint (pe-kv-*) and a linked private DNS zone
# (privatelink.vaultcore.azure.net). Containers inside the VNet resolve the KV
# hostname to the private endpoint IP, so public access can be safely disabled.
#
# Guard: verify the private endpoint actually exists before locking — this
# prevents startup failures if someone runs the script against an environment
# where the KV private endpoint was not provisioned (e.g. VNet disabled later).
$kvName = azd env get-value keyVaultName 2>$null
if ($LASTEXITCODE -ne 0) { $kvName = $null }
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
