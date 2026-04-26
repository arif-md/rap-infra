#!/bin/bash

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

set -euo pipefail

VNET_ENABLED=$(azd env get-value ENABLE_VNET_INTEGRATION 2>/dev/null || true)
if [ "$VNET_ENABLED" != "true" ]; then
    echo "VNet not enabled — network lockdown skipped."
    exit 0
fi

RG=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || true)
if [ -z "$RG" ]; then
    echo "AZURE_RESOURCE_GROUP not set — skipping network lockdown."
    exit 0
fi

echo "==> Locking public network access (VNet mode)..."

# ── App Configuration ────────────────────────────────────────────────────────
# App Config has no "trusted Azure services" bypass: ARM deployment engine
# writes key-values over the public endpoint, so we keep public access open
# during Bicep deployment and lock it down here in postprovision.
APP_CONFIG_NAME=$(azd env get-value appConfigName 2>/dev/null || true)
if [ -n "$APP_CONFIG_NAME" ]; then
    echo "  Disabling App Config public access: $APP_CONFIG_NAME"
    az appconfig update \
        --name "$APP_CONFIG_NAME" \
        --resource-group "$RG" \
        --enable-public-network false \
        --output none
    echo "  ✅ App Config public access disabled."
else
    echo "  WARNING: appConfigName not in azd env — skipping App Config lockdown."
fi

# ── Key Vault ────────────────────────────────────────────────────────────────
# Key Vault has a private endpoint (pe-kv-*) and a linked private DNS zone
# (privatelink.vaultcore.azure.net). Containers inside the VNet resolve the KV
# hostname to the private endpoint IP, so public access can be safely disabled.
#
# Guard: verify the private endpoint actually exists before locking — this
# prevents startup failures if someone runs the script against an environment
# where the KV private endpoint was not provisioned.
KV_NAME=$(azd env get-value kvName 2>/dev/null || true)
if [ -n "$KV_NAME" ]; then
    KV_PE_NAME="pe-${KV_NAME}"
    KV_PE_STATE=$(az network private-endpoint show -g "$RG" -n "$KV_PE_NAME" \
        --query "provisioningState" -o tsv 2>/dev/null || true)
    if [ "$KV_PE_STATE" = "Succeeded" ]; then
        echo "  Disabling Key Vault public access: $KV_NAME"
        az keyvault update \
            --name "$KV_NAME" \
            --resource-group "$RG" \
            --public-network-access Disabled \
            --output none
        echo "  ✅ Key Vault public access disabled."
    else
        echo "  Key Vault: private endpoint '$KV_PE_NAME' not found or not Succeeded — public access left enabled."
        echo "             Run 'azd provision' to create the private endpoint, then re-run this script."
    fi
else
    echo "  WARNING: kvName not in azd env — skipping Key Vault lockdown."
fi

echo "==> Network lockdown complete."
